#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2240, from device log 115 (2026-10-28): a game's first-run install script ran the DirectX
redistributable, whose x64 helper (64 KB, relocations stripped, base 0x100000000) cannot be mapped at its base:
the task's floor sits a slide above 4 GB. ntdll refused it with c0000018 and the script stopped.

- build/ntdll-unix/signal_arm64_ios.c: a window between 4 GB and the floor is allowed when fixed allocations at
  its first and last page answer KERN_INVALID_ADDRESS (env.MADEIRA_SUBFLOOR_HIGH=0 restores the 4 GB limit); the
  translate fast path rejects above the highest window's end;
- build/ntdll-unix/virtual_ios.c: such an image's header names its real base (ml1195), its window is registered,
  and it is pushed to FEX with bit 63 set (FEX/Source/Windows/ARM64EC/IosJitAlias.cpp files it as a window).

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sig = (ROOT / 'build/ntdll-unix/signal_arm64_ios.c').read_text(encoding='utf-8', errors='replace')
virt = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

ok = body(sig, 'int ios_subfloor_high_ok( unsigned long long base, unsigned long long size )\n{')
check('getenv( "MADEIRA_SUBFLOOR_HIGH" )' in ok and "enabled = !(e && e[0] == '0');" in ok,
      'env.MADEIRA_SUBFLOOR_HIGH=0 restores the 4 GB limit, default on')
check('return ios_subfloor_high_probe( base, page ) && ios_subfloor_high_probe( end - page, page );' in ok
      and 'end > IOS_SUBFLOOR_HIGH_MAX' in ok and 'base < IOS_SUBFLOOR_FLOOR' in ok,
      'the first and the last page of the range are probed, below a fixed bound')
probe = body(sig, 'static int ios_subfloor_high_probe(')
check('VM_FLAGS_FIXED' in probe and 'return kr == KERN_INVALID_ADDRESS;' in probe
      and 'if (kr == KERN_SUCCESS) mach_vm_deallocate(' in probe,
      'only "outside the map" passes; a successful probe allocation is given back')
reg = body(sig, 'void ios_register_subfloor_image( unsigned long long pref_base, unsigned long long size,\n                                  unsigned long long real_base, void *owner )\n{')
check('if (pref_base >= IOS_SUBFLOOR_FLOOR && !ios_subfloor_high_ok( pref_base, size )) return;' in reg
      and reg.index('__atomic_store_n( &ios_subfloor_ceiling') < reg.index('ios_subfloor[i].size = size;'),
      'registration above 4 GB needs the probe; the ceiling is raised before a window is published')
tr = body(sig, 'static uintptr_t ios_subfloor_translate( uint64_t addr, void *peb )\n{')
check('if (addr >= __atomic_load_n( &ios_subfloor_ceiling, __ATOMIC_ACQUIRE )) return 0;' in tr,
      'the translate fast path rejects above the highest window')

check('(image_info->base < 0x100000000ull || ios_subfloor_high_ok( image_info->base, total_size ))' in virt,
      'ml1195 rewrites the header of such an image')
check('[subfloor] ml2240 image based at' in virt and 'nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&\n'
      '        (nt->FileHeader.Characteristics & IMAGE_FILE_RELOCS_STRIPPED) &&\n'
      '        ios_subfloor_high_ok( image_info->base, total_size ))' in virt,
      'a 64-bit RELOCS_STRIPPED image above 4 GB gets its window')
push = body(virt, 'void ios_push_subfloor_window( unsigned long long low_base, unsigned long long real_base,')
check(push.count('low_base >= 0x100000000ull ? low_base | (1ull << 63) : low_base') == 2,
      'both FEX pushes mark a window above 4 GB with bit 63')

fex = ROOT / 'FEX/Source/Windows/ARM64EC/IosJitAlias.cpp'
if fex.exists():
    f = fex.read_text(encoding='utf-8', errors='replace')
    check('if (PeBase & kIosSubfloorHighMark) {' in f and 'IosSubfloorAdd(PeBase & ~kIosSubfloorHighMark, JitBase, Size);' in f,
          'FEX files a marked window in its window table')
    check('if (Addr >= __atomic_load_n(&g_SubfloorCeiling, __ATOMIC_ACQUIRE)) {' in f,
          "FEX's low -> real fast path follows the ceiling")
else:
    print('SKIP: FEX sources not checked out')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('MADEIRA_SUBFLOOR_HIGH', 'MADEIRA_BIG_PICTURE_DOCK_LIBRARIES'):
        check(f'key: "env.{key}"' in text, f'the config catalog documents env.{key}')

print(f'check-subfloor-high: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
