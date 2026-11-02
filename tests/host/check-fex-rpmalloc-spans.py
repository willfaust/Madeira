#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2020: the emulator's allocator (FEX/External/rpmalloc/rpmalloc/rpmalloc.c, the iOS host
geometry) reserves 4 MB spans, so a guest thread's heap costs 12 MB of the FEX arena instead of
48 MB. Static anchors on the source, plus the marker strings in the two shipped emulator
modules (the ARM64EC module xtajit64.dll and the WoW64 module xtajit.dll embed this allocator).

Native proof: build FEX/External/rpmalloc/test/main.c against rpmalloc.c with
-DRPMALLOC_IOS_SMALL_SPANS=1 (stubs for the two Win32 calls and FEX_AllocWatch_*); the suite
passes once its 3151000-byte realloc, which sits above the 2 MB large ceiling, is lowered.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'FEX/External/rpmalloc/rpmalloc/rpmalloc.c'
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

if not SRC.exists():
    print('SKIP: the FEX submodule is not checked out here')
    sys.exit(0)
src = SRC.read_text(encoding='utf-8', errors='replace')

check(re.search(r'#if defined\(FEX_IOS_HOST\) && !defined\(RPMALLOC_IOS_SMALL_SPANS\)\s*\n#define RPMALLOC_IOS_SMALL_SPANS 1', src) is not None,
      'the iOS host build selects the small-span geometry, and a native test build can select it alone')
geom = {
    'SPAN_SIZE (4 * 1024 * 1024)': 'spans are 4 MB',
    'LARGE_PAGE_SIZE_SHIFT 22': 'one 4 MB large page per span',
    'MEDIUM_PAGE_SIZE_SHIFT 20': 'four 1 MB medium pages per span',
    'LARGE_BLOCK_SIZE_LIMIT (2 * 1024 * 1024)': 'the large class ceiling is 2 MB (bigger blocks map exactly)',
    'LARGE_SIZE_CLASS_COUNT 12': 'twelve large classes, up to 2 MB',
}
for anchor, text in geom.items():
    block = src[max(0, src.index(anchor) - 1400):src.index(anchor)] if anchor in src else ''
    check(anchor in src and 'RPMALLOC_IOS_SMALL_SPANS' in block, text + ' (under the small-span switch)')
check('static const char ios_span4_marker[] __attribute__((used)) = "rpmalloc-span4 rev=ml2020";' in src,
      'the marker string names the geometry in a built module')
table = src[src.index('static const size_class_t global_size_class[SIZE_CLASS_COUNT]'):src.index('global_page_free_overflow')]
check('LCLASS(131072),\n#ifndef RPMALLOC_IOS_SMALL_SPANS' in table and 'LCLASS(524288)\n#endif' in table,
      'the size-class table ends at the 2 MB class in the small-span geometry (the 8 MB stock tail is kept for other builds)')
check('#define SPAN_SIZE (256 * 1024 * 1024)' in src and '#define LARGE_PAGE_SIZE_SHIFT 26' in src
      and '#define MEDIUM_PAGE_SIZE_SHIFT 22' in src and '#define LARGE_BLOCK_SIZE_LIMIT (8 * 1024 * 1024)' in src,
      'the stock geometry is untouched for builds without the switch')

for rel in ('app/Madeira/arm64ec-windows/xtajit64.dll', 'app/Madeira/aarch64-windows/xtajit.dll'):
    p = ROOT / rel
    if not p.exists():
        print(f'SKIP: {rel} is not in this checkout')
        continue
    data = p.read_bytes()
    check(b'rpmalloc-span4 rev=ml2020' in data, f'{rel} was built from the small-span allocator')
    if rel.endswith('xtajit.dll'):
        check(b'[smc-hot] wow64: hot SMC pages' in data,
              f'{rel} enables hot self-modifying-code pages (FEX/Source/Windows/WOW64/Module.cpp, ml2020)')

print(f'check-fex-rpmalloc-spans: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
