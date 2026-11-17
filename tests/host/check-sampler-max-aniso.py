#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""madeira.cfg sampler-max-aniso = N: the D3D12 runtime caps the anisotropy of the Metal samplers it makes.

Static anchors: the key's parse (1..16, anything else off), the cap in mad_sampler_info (the one place a D3D12
sampler becomes a WMTSamplerInfo, for static samplers and CreateSampler alike), applied after the game's value
is read and only to anisotropic filters, and that the root-signature data the converter and the shader cache
hash (struct mad_static_sampler / the serialized words) is not rewritten. A model of the cap is run on values.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
pe = (ROOT / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start, end='\n}\n'):
    i = pe.index(start)
    return pe[i:pe.index(end, i + len(start))]

load = body('static void mad_sampler_red_load(void) {')
check('a = mad_cfg_int_pe("sampler-max-aniso", 0);' in load and 'g_smp_aniso = a >= 1 && a <= 16 ? (int)a : 0;' in load,
      'sampler-max-aniso is read with default 0; only 1..16 turns the cap on')
check(load.index('g_smp_aniso = ') < load.index('g_smp_red = v >= 1'),
      'the cap is stored before g_smp_red marks the settings as loaded')
info = body('float minlod, float maxlod, const char *who) {\n', '\n}\n')
asked = 'si->max_anisotroy = (filter & 0x40) ? (aniso ? aniso : 16) : 1;'
check(asked in info and 'if (asked > (unsigned)g_smp_aniso) {' in info
      and info.index(asked) < info.index('si->max_anisotroy = g_smp_aniso;'),
      'the cap lowers maxAnisotropy after the game\'s value is taken, and never raises it')
check(info.index('if ((filter & 0x40) && g_smp_aniso) {   /* madeira-duo sampler-max-aniso') < info.index('si->max_anisotroy = g_smp_aniso;'),
      'only anisotropic filters are touched, and only with the cap set (unset: no count, no log line)')
check(info.index('if (g_smp_red < 0) mad_sampler_red_load();') < info.index(asked), 'the settings are loaded before the first sampler is made')
check(pe.count('= g_smp_aniso;') == 1 and 'si->max_anisotroy = g_smp_aniso;' in info,
      'the root-signature sampler data the converter hashes is left as the game gave it')

def metal(filter_, aniso, cap):
    v = (aniso if aniso else 16) if filter_ & 0x40 else 1
    if filter_ & 0x40 and cap and v > cap: v = cap
    return v
check([metal(0x55, 8, c) for c in (0, 1, 2, 4, 8, 16)] == [8, 1, 2, 4, 8, 8] and metal(0x55, 0, 4) == 4
      and metal(0x15, 8, 1) == 1 and metal(0x55, 2, 4) == 2 and metal(0xd5, 16, 1) == 1,
      'model: 8x under caps 0/1/2/4/8/16 -> 8/1/2/4/8/8; a linear filter stays 1; a lower request is kept')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('key: "sampler-max-aniso"' in catalog.read_text(encoding='utf-8'), 'the config catalog documents sampler-max-aniso')

print(f'check-sampler-max-aniso: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
