#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[vdcfg] env.MADEIRA_VDCFG_PATH: QueryDisplayConfig lists the virtual monitor's path (the one active monitor
without a source), as GetDisplayConfigBufferSizes already counts it, and DisplayConfigGetDeviceInfo names its
source, target and adapter (build/win32u-unix/sysparams_ios.c).

Static anchors only: the switch is read once and accepts 1/on/true/yes, the sourceless test lets only the virtual
monitor through and only when on, the path uses the virtual adapter LUID and source 0, the three device-info
answers it adds are gated, and the [vdcfg] / [vdcfg-mismatch] lines.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/win32u-unix/sysparams_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

en = body('static int ios_vdcfg_path_enabled(void)')
check('static int on = -1;' in en and re.search(r'const char \*e = getenv\( "MADEIRA_VDCFG_PATH" \);', en) is not None,
      'the switch is read once')
check('on = e && (!strcmp( e, "1" ) || !strcasecmp( e, "on" ) || !strcasecmp( e, "true" ) || !strcasecmp( e, "yes" ));' in en,
      'only 1/on/true/yes turn it on (default off)')
check('"[vdcfg] MADEIRA_VDCFG_PATH=1: QueryDisplayConfig lists the virtual monitor\'s path (the count "' in en,
      'logged once as [vdcfg] when on')
check('return key_on && sourceless && is_virtual_monitor;'
      in body('static int ios_vdcfg_lists_sourceless( int key_on, int sourceless, int is_virtual_monitor )'),
      'a sourceless monitor is listed only when on and only if it is the virtual monitor')

qdc = src[src.index('if (!ios_vdcfg_lists_sourceless( ios_vdcfg_path_enabled(), 1, monitor == &virtual_monitor ))'):][:1600]
check('skipped++;' in qdc and 'virtual_path = TRUE;' in qdc, 'QueryDisplayConfig: off, the monitor is skipped as before')
check('source_index = 0;' in qdc and 'ios_virtual_luid_locked( &virtual_luid );' in qdc and 'gpu_luid = &virtual_luid;' in qdc,
      "QueryDisplayConfig: the listed path is source 0 on the virtual adapter's LUID")
check('if (ret != STATUS_SUCCESS && ios_vdcfg_path_enabled() && !source_name->header.id)' in src
      and 'asciiz_to_unicode( source_name->viewGdiDeviceName, "\\\\\\\\.\\\\DISPLAY1" );' in src,
      'source name: only on, only for id 0 on the virtual LUID, answered as \\\\.\\DISPLAY1')
check('if (!monitor->source && ios_vdcfg_lists_sourceless( ios_vdcfg_path_enabled(), 1, monitor == &virtual_monitor ))' in src,
      'target name: the virtual monitor is found by the same sourceless test')
check('if (ret != STATUS_SUCCESS && ios_vdcfg_path_enabled())' in src
      and 'if (!memcmp( &adapter_name->header.adapterId, &virtual_luid, sizeof(virtual_luid) ))' in src,
      'adapter name: only on, only for the virtual LUID')
check(src.count('ios_vdcfg_path_enabled()') == 4, 'the switch has four gates: the path and three device-info answers')
check('"[vdcfg-mismatch] QueryDisplayConfig flags=%#x answered success with 0 paths 0 modes' in src
      and 'if (ret == ERROR_SUCCESS && !path_index && ios_vdcfg_sizes_paths)' in src,
      'off, the disagreement with the sizes call is logged as [vdcfg-mismatch]')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_VDCFG_PATH"' in text, 'the config catalog documents env.MADEIRA_VDCFG_PATH')

print(f'check-vdcfg-path-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
