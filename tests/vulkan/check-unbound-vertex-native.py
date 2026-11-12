#!/usr/bin/env python3
"""Regression for real zero input fetch, restored descriptors and default-off policy.
This is an implementation compatibility test for otherwise undefined inputs.
"""
from pathlib import Path
import os,subprocess,sys,tempfile
headers,library=map(lambda x:Path(x).resolve(),sys.argv[1:3])
source=Path(__file__).with_name('unbound-vertex-probe.c')
with tempfile.TemporaryDirectory(prefix='madeira-unbound-vertex-') as d:
 exe=Path(d)/'probe'
 subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-I'+str(headers),str(source),str(library),'-Wl,-rpath,'+str(library.parent),'-o',str(exe)],check=True)
 for enabled in ['0','1']:
  run=subprocess.run([str(exe)],env=dict(os.environ,MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS=enabled,MVK_CONFIG_LOG_LEVEL='2'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
  print('POLICY',enabled,run.stdout,sep='\n');assert run.returncode==0,run.stdout
  assert 'GPU readback expected=3f400000 actual=3f400000' in run.stdout
  assert 'GPU readback expected=2f603040 actual=2f603040' in run.stdout
  if enabled=='1':
   assert 'round=1 missing=1 create=0' in run.stdout
   assert 'round=3 missing=1 create=0' in run.stdout
   assert 'same-encoder outputs missing=00000000 prime=2f603040' in run.stdout
  else:assert 'round=1 missing=1 create=-3' in run.stdout
 for kind in ['1','2']:
  run=subprocess.run([str(exe),kind],env=dict(os.environ,MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS='1',MVK_CONFIG_LOG_LEVEL='2'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
  print('TYPE',kind,run.stdout,sep='\n');assert run.returncode==0,run.stdout
  assert 'round=1 GPU readback expected=00000000 actual=00000000' in run.stdout
print('PASS native real GPU zero input and unaffected valid data, default-off and same-encoder transitions')
