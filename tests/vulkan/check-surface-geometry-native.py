#!/usr/bin/env python3
"""Native macOS MoltenVK geometry regression; not a real-iPad result.
Usage: python3 check-surface-geometry-native.py INCLUDE LIBMOLTENVK.dylib
Legacy geometry must fail the stable acquisition requirement. Production
geometry must pass, while a real resize still reports native SUBOPTIMAL.
"""
from pathlib import Path
import subprocess,sys,tempfile,os
headers=Path(sys.argv[1]).resolve();library=Path(sys.argv[2]).resolve()
source=Path(__file__).with_name('surface-geometry-probe.m')
with tempfile.TemporaryDirectory() as t:
 for legacy in [True,False]:
  exe=Path(t)/('legacy' if legacy else 'fixed')
  command=['xcrun','clang','-fobjc-arc','-Wall','-Wextra','-Werror','-I',str(headers),str(source),str(library),'-Wl,-rpath,'+str(library.parent),'-framework','Foundation','-framework','QuartzCore','-framework','Metal','-framework','CoreGraphics','-o',str(exe)]
  if legacy:command.insert(2,'-DMADEIRA_TEST_LEGACY')
  subprocess.run(command,check=True)
  r=subprocess.run([str(exe)],env=dict(os.environ,MVK_CONFIG_LOG_LEVEL='2'),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  print(r.stdout,flush=True)
  assert r.returncode==(3 if legacy else 0),(legacy,r.returncode)
  assert 'fixed=1 frame=320x180 bounds='+('320x180' if legacy else '640x360') in r.stdout
  if not legacy:assert 'fixed=2 frame=400x225 bounds=800x450' in r.stdout and 'acquire=1000001003' in r.stdout
print('PASS: native baseline reproduces false SUBOPTIMAL; production geometry fixes stable extent and preserves real resize status')
