#!/usr/bin/env python3
"""Check tessellation shader handling without running the Metal compiler."""
from pathlib import Path
import os
import subprocess
import tempfile

script = Path(__file__).resolve().parents[2] / 'tools/build/build-shader-headers.sh'
old = '  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);\n'
upstream = '  return atomic_fetch_add_explicit(reinterpret_cast<threadgroup atomic_int *>(out_count), 1, memory_order_relaxed);\n'

with tempfile.TemporaryDirectory(prefix='madeira-shader-test-') as tmp:
    root = Path(tmp)
    src = root / 'dxmt/src/airconv/shaders'
    src.mkdir(parents=True)
    tools = root / 'bin'
    tools.mkdir()
    (tools / 'xcrun').write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; : > "$1"; exit 0; fi; shift; done\nexit 1\n')
    (tools / 'xxd').write_text('#!/bin/sh\nfor last do :; done\n: > "$last"\n')
    for tool in tools.iterdir():
        tool.chmod(0o755)
    for name in ('air_msad', 'air_samplepos'):
        (src / (name + '.metal')).write_text('// fixture\n')
    shader = src / 'air_tessellation.metal'
    env = dict(os.environ, ROOT=str(root), PATH=str(tools) + os.pathsep + os.environ['PATH'])
    for source in (old, upstream, '// unsupported shader\n'):
        shader.write_text(source)
        result = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
        if source == old:
            assert result.returncode == 0, result.stderr
            assert '__METAL_MEMORY_FLAGS_NONE__' in shader.read_text()
        elif source == upstream:
            assert result.returncode == 0, result.stderr
            assert shader.read_text() == source
        else:
            assert result.returncode != 0 and 'expected atomic call not found' in result.stderr
print('tessellation shader handling passes')
