#!/usr/bin/env python3
"""DXMT's Direct3D 9 format gate lets the luminance formats be render targets.

A program that builds one-channel targets (ambient occlusion, blur passes,
masks) through its engine's format table asks CreateTexture for D3DFMT_L8
with D3DUSAGE_RENDERTARGET. isColorRTFormat() in dxmt/src/d3d9/d3d9_format.cpp
refused it ("CreateTexture: format 50 not render-target-capable"), the
engine got no target and the program sat on its loading screen with both of
its threads parked. Native drivers and DXVK allow L8 targets: the storage
(R8Unorm) is colour-renderable on every Metal GPU.

Checks, on the source:
  - isColorRTFormat() returns true for D3DFMT_L8, D3DFMT_A8L8 and D3DFMT_L16
    behind the MADEIRA_D3D9_LUMINANCE_RT switch (0 = refuse, as before);
  - the three formats still map to a colour-renderable Metal format for the
    render-target usage (D3DFormatToMetal only rejects them for depth);
  - the config catalog carries the switch.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
fmt = (root / 'dxmt/src/d3d9/d3d9_format.cpp').read_text(encoding='utf-8', errors='replace')
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text(encoding='utf-8', errors='replace')
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print('FAIL:', what)


m = re.search(r'\nbool\nisColorRTFormat\(D3DFORMAT format\) \{(.*?)\n\}\n', fmt, re.S)
check(m, 'isColorRTFormat() not found')
body = m.group(1) if m else ''
lum = re.search(r'case D3DFMT_L8:\s*case D3DFMT_A8L8:\s*case D3DFMT_L16: \{(.*?)\n  \}', body, re.S)
check(lum, 'isColorRTFormat() lacks the L8 / A8L8 / L16 case')
if lum:
    check('env::getEnvVar("MADEIRA_D3D9_LUMINANCE_RT") != "0"' in lum.group(1)
          and 'return luminanceRT;' in lum.group(1),
          'the luminance case must return the MADEIRA_D3D9_LUMINANCE_RT switch (default on)')
check('#include "util_env.hpp"' in fmt, 'd3d9_format.cpp must include util_env.hpp for the switch')

for name, metal in (('D3DFMT_L8', 'WMTPixelFormatR8Unorm'), ('D3DFMT_A8L8', 'WMTPixelFormatRG8Unorm'),
                    ('D3DFMT_L16', 'WMTPixelFormatR16Unorm')):
    mm = re.search(r'case %s:.*?return usage == D3D9FormatUsage::DepthStencil \? WMTPixelFormatInvalid : (\w+);'
                   % name, fmt, re.S)
    check(mm and mm.group(1) == metal,
          '%s must map to %s for every usage but depth (got %s)' % (name, metal, mm.group(1) if mm else None))

check('key: "env.MADEIRA_D3D9_LUMINANCE_RT"' in catalog and 'defaultValue: "1"' in
      catalog[catalog.find('key: "env.MADEIRA_D3D9_LUMINANCE_RT"'):][:400],
      'ConfigCatalog.generated.swift lacks env.MADEIRA_D3D9_LUMINANCE_RT (default 1)')

if failures:
    print('%d failure(s)' % len(failures))
    sys.exit(1)
print('OK: L8 / A8L8 / L16 render targets allowed behind MADEIRA_D3D9_LUMINANCE_RT')
