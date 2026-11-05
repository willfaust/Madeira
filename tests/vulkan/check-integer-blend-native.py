#!/usr/bin/env python3
"""Compile and run real Vulkan against the supplied native macOS MoltenVK.
Usage: python3 check-integer-blend-native.py INCLUDE_DIR LIBMOLTENVK.dylib
Not a fixture test or an iPad result.
"""
from pathlib import Path
import subprocess,sys,tempfile,os
headers=Path(sys.argv[1]).resolve();library=Path(sys.argv[2]).resolve()
source=Path(__file__).with_name('integer-blend-probe.c')
with tempfile.TemporaryDirectory() as t:
 for enabled in [0,1]:
  exe=Path(t)/f'blend-{enabled}'
  subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror',f'-DINTEGER_BLEND_ENABLE={enabled}','-I',str(headers),str(source),str(library),'-Wl,-rpath,'+str(library.parent),'-o',str(exe)],check=True)
  r=subprocess.run([str(exe)],env=dict(os.environ,MVK_CONFIG_LOG_LEVEL='2'),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  print(r.stdout,flush=True)
  assert r.returncode==0, f'Native pipeline failed: {r.returncode}'
  warnings=r.stdout.count('Blending is enabled for attachment with format VK_FORMAT_R32_UINT')
  assert warnings == enabled, f'blendEnable={enabled}: expected {enabled} warning, observed {warnings}'
print('PASS: disabled integer blending is quiet; requested unsupported blending still warns')
