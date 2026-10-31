#!/usr/bin/env python3
"""Run real MoltenVK cache and converter regressions; no game data or mock driver."""
from pathlib import Path
import subprocess,sys,tempfile
headers,library,source=map(lambda s:Path(s).resolve(),sys.argv[1:4])
here=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='madeira-vertex-reuse-') as d:
 for name,cmd in [('pipeline',['xcrun','clang','-std=c11','-I'+str(headers),str(here/'vertex-cache-reuse-probe.c')]),('converter',['xcrun','clang++','-std=c++17','-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross','-I'+str(source/'MoltenVKShaderConverter/MoltenVKShaderConverter'),'-I'+str(source/'External/SPIRV-Cross'),str(here/'vertex-converter-probe.cpp')])]:
  exe=Path(d)/name;subprocess.run([*cmd,str(library),'-Wl,-rpath,'+str(library.parent),'-o',str(exe)],check=True);subprocess.run([str(exe)],check=True)
