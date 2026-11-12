#!/usr/bin/env python3
"""Real MoltenVK cache lifetime/size regressions; requires an actual Metal GPU."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

headers, library = (Path(arg).resolve() for arg in sys.argv[1:3])
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='madeira-vulkan-cache-memory-') as directory:
    for name, cases in [('budget', [(8, 8), (1, 4), (256, 256)]),
                        ('specialization', [(8, 8), (256, 8)])]:
        exe = Path(directory) / name
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-I' + str(headers), str(root / ('tests/x64/vulkan-cache-' + name + '.c')),
                        str(library), '-Wl,-rpath,' + str(library.parent), '-o', str(exe)], check=True)
        for limit, count in cases:
            subprocess.run([str(exe), str(count)], check=True,
                           env=dict(os.environ, MADEIRA_VK_SHADER_CACHE_MAX_LIBRARIES=str(limit)))
print('PASS bounded caches, concurrent access, merged specialization lifetime and real GPU readbacks')
