#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[d3d12-caps] env.MADEIRA_D3D12_CAPS_BY_FAMILY: CheckFeatureSupport claims 64-bit atomics only on Apple9 GPUs
and wave operations only from Apple7, instead of on every GPU (madeira-d3d12/src/pe/madeira_d3d12.c).

Static anchors only: the switch is read once from the PE environment and only "1" turns it on, the family
thresholds, and the three answers it narrows (OPTIONS1 WaveOps, OPTIONS9 and OPTIONS11 64-bit atomics), each of
which keeps its old value without the switch.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

reader = body('static int mad_caps_by_family(void) {')
check('static int v = -1;' in reader and 'GetEnvironmentVariableA("MADEIRA_D3D12_CAPS_BY_FAMILY", e, sizeof e);' in reader,
      'the switch is read once from the environment')
check("v = n == 1 && e[0] == '1';" in reader, 'only the value 1 turns it on (unset, 0 or anything longer: off)')
check('"[d3d12-caps]' in reader and '(MADEIRA_D3D12_CAPS_BY_FAMILY): 64-bit atomics "' in reader, 'logged once as [d3d12-caps] when on')

check('return g_target.family >= MAD_IR_FAMILY_APPLE7;' in body('static int mad_family_wave_ops(struct mad_device *d) {')
      and 'mad_resolve_target(d);' in body('static int mad_family_wave_ops(struct mad_device *d) {'),
      'wave operations from Apple7, judged on the conversion target')
check('return g_target.family >= MAD_IR_FAMILY_APPLE9;' in body('static int mad_family_atomics64(struct mad_device *d) {'),
      '64-bit atomics from Apple9')

cfs = src[src.index('static HRESULT STDMETHODCALLTYPE device_CheckFeatureSupport(ID3D12Device *This,'):]
o1 = cfs[cfs.index('D3D12_FEATURE_DATA_D3D12_OPTIONS1 *o = data;'):]
o1 = o1[:o1.index('return S_OK;')]
check('if (o->WaveOps && mad_caps_by_family() && !mad_family_wave_ops((struct mad_device *)This))' in o1
      and 'o->WaveOps = FALSE;' in o1, 'OPTIONS1: WaveOps is withdrawn below Apple7 only with the switch')
o9 = cfs[cfs.index('case D3D12_FEATURE_D3D12_OPTIONS9: {'):]
o9 = o9[:o9.index('case D3D12_FEATURE_D3D12_OPTIONS11: {')]
check(re.search(r'if \(mad_caps_by_family\(\) && !mad_family_atomics64\(\(struct mad_device \*\)This\)\)\s*return S_OK;', o9) is not None
      and o9.index('memset(o, 0, sizeof *o);') < o9.index('mad_caps_by_family()')
      < o9.index('o->AtomicInt64OnTypedResourceSupported = TRUE;'),
      'OPTIONS9: below Apple9 the zeroed answer is returned before the 64-bit atomic claims')
o11 = cfs[cfs.index('case D3D12_FEATURE_D3D12_OPTIONS11: {'):]
o11 = o11[:o11.index('return S_OK;')]
check(o11.index('o->AtomicInt64OnDescriptorHeapResourceSupported = TRUE;')
      < o11.index('if (mad_caps_by_family() && !mad_family_atomics64((struct mad_device *)This))')
      and 'o->AtomicInt64OnDescriptorHeapResourceSupported = FALSE;' in o11,
      'OPTIONS11: the descriptor-heap 64-bit atomic claim is withdrawn below Apple9 only with the switch')
check(src.count('mad_caps_by_family()') == 3, 'the switch narrows exactly these three answers')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_D3D12_CAPS_BY_FAMILY"' in text, 'the config catalog documents env.MADEIRA_D3D12_CAPS_BY_FAMILY')

print(f'check-d3d12-caps-by-family: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
