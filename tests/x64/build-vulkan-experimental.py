#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Build standalone and correctly linked composite Windows x64 Vulkan probes."""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', type=Path, default=root / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang')
parser.add_argument('--headers', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not args.compiler.is_file() or not (args.headers / 'vulkan/vulkan.h').is_file():
    raise SystemExit('Provide the existing x86_64 llvm-mingw compiler and pinned Vulkan headers')
out = args.output.resolve()
obj = out / 'objects'
obj.mkdir(parents=True, exist_ok=True)
# llvm-mingw's target wrapper selects its triple from argv[0]; keep its symlink name.
flags = [str(args.compiler.absolute()), '-O2', '-Wall', '-Wextra', '-Werror', '-I' + str(args.headers.resolve())]

def compile_object(source, name, *defines):
    path = obj / (name + '.o')
    subprocess.run(flags + ['-D' + define for define in defines] + ['-c', str(root / source), '-o', str(path)], check=True)
    return path

def link(name, *inputs):
    subprocess.run(flags + [str(p) for p in inputs] + ['-luser32', '-o', str(out / name)], check=True)
    print('BUILT', name)

clear = compile_object('tests/x64/vulkan-smoke.c', 'clear', 'VULKAN_CLEAR_TEST', 'main=vulkan_clear_main')
vertex = compile_object('tests/x64/vulkan-vertex-cache.c', 'vertex', 'main=vulkan_vertex_cache_main')
reuse = compile_object('tests/vulkan/vertex-cache-reuse-probe.c', 'reuse', 'main=vulkan_vertex_reuse_main')
cache = compile_object('tests/x64/vulkan-cache-export.c', 'export', 'main=vulkan_cache_export_main')
present = compile_object('tests/x64/vulkan-present.c', 'present', 'main=vulkan_present_main')
budget = compile_object('tests/x64/vulkan-cache-budget.c', 'budget', 'main=vulkan_cache_budget_main')
specialization = compile_object('tests/x64/vulkan-cache-specialization.c', 'specialization', 'main=vulkan_cache_specialization_main')
handoff = compile_object('tests/x64/vulkan-cache-handoff.c', 'handoff')
windows = compile_object('tests/x64/windows-handoff.c', 'windows')
link('vulkan-enumerate-x64.exe', root / 'tests/x64/vulkan-smoke.c')
subprocess.run(flags + ['-DVULKAN_CLEAR_TEST', str(root / 'tests/x64/vulkan-smoke.c'), '-o', str(out / 'vulkan-clear-x64.exe')], check=True)
print('BUILT vulkan-clear-x64.exe')
link('vulkan-present-x64.exe', root / 'tests/x64/vulkan-present.c')
link('vulkan-cache-budget-x64.exe', root / 'tests/x64/vulkan-cache-budget.c')
link('vulkan-cache-specialization-x64.exe', root / 'tests/x64/vulkan-cache-specialization.c')
link('vulkan-memory-regression-x64.exe', root / 'tests/x64/vulkan-memory-regression.c', budget, specialization)
link('vulkan-postcompile-x64.exe', root / 'tests/x64/vulkan-postcompile.c', handoff, windows, present)
link('vulkan-regression-all-x64.exe', root / 'tests/x64/vulkan-regression-all.c', clear, vertex, reuse, cache, present)
print('PASS eight Windows x64 test executables built; no runtime/device pass implied')
