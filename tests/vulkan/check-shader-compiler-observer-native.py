#!/usr/bin/env python3
"""Verify bounded opt-in diagnostics against real Metal compilation/GPU readback.

Usage: check-shader-compiler-observer-native.py HEADERS LIBMOLTENVK SOURCE
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

headers, library, source = (Path(p).resolve() for p in sys.argv[1:4])
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='madeira-compiler-observer-') as temp:
    ledger = Path(temp) / 'ledger'
    subprocess.run([
        'xcrun', 'clang++', '-std=c++17', '-Wno-deprecated-declarations',
        '-I' + str(source / 'MoltenVK/MoltenVK/GPUObjects'),
        str(root / 'tests/vulkan/shader-compiler-ledger.mm'),
        '-framework', 'Foundation', '-framework', 'Metal', '-o', str(ledger),
    ], check=True)
    subprocess.run([str(ledger)], check=True)

    exe = Path(temp) / 'probe'
    subprocess.run([
        'xcrun', 'clang', '-std=c11', '-I' + str(headers),
        str(root / 'tests/x64/vulkan-cache-budget.c'), str(library),
        '-Wl,-rpath,' + str(library.parent), '-o', str(exe),
    ], check=True)
    env = dict(os.environ, MADEIRA_VK_SHADER_CACHE_MAX_LIBRARIES='256',
               MVK_CONFIG_LOG_LEVEL='1')
    for mode in ['unset', '0', '1']:
        if mode == 'unset':
            env.pop('MADEIRA_VK_SHADER_COMPILE_DIAGNOSTICS', None)
        else:
            env['MADEIRA_VK_SHADER_COMPILE_DIAGNOSTICS'] = mode
        result = subprocess.run([str(exe), '256'], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print('OBSERVER MODE:', mode)
        print(result.stdout)
        assert result.returncode == 0, 'Real GPU regression failed'
        summaries = re.findall(
            r'\[vk-compiler\] completed=(\d+) unique=(\d+) repeated=(\d+) '
            r'untracked=(\d+) failed=(\d+)', result.stdout)
        if mode != '1':
            assert not summaries, 'Observer not disabled'
        else:
            assert summaries, 'Opt-in compiler summaries are absent'
            completed, unique, repeated, untracked, failed = map(int, summaries[-1])
            assert completed >= 2048 and unique > 0 and repeated > 0
            assert unique + repeated == completed and untracked == 0 and failed == 0
    specialized = Path(temp) / 'specialization'
    subprocess.run([
        'xcrun', 'clang', '-std=c11', '-I' + str(headers),
        str(root / 'tests/x64/vulkan-cache-specialization.c'), str(library),
        '-Wl,-rpath,' + str(library.parent), '-o', str(specialized),
    ], check=True)
    # Exercise the observer on actual specialization macro NSNumber values.
    subprocess.run([str(specialized), '8'], env=env, check=True)
print('PASS default-off/opt-in observer, duplicate inputs and unchanged GPU readback')
